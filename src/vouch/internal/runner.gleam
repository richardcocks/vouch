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
    option.Some(pattern) -> string.contains(module <> "." <> function, pattern)
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
pub fn run(
  rep: Reporter(s),
  filter: Option(String),
  timeout_ms: Int,
  parallel: config.Parallelism,
) -> Nil {
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
  let #(state, outcomes) = case workers(parallel) {
    1 -> run_sequential(rep, state, tests, timeout_ms)
    n -> run_window(rep, tests, [], 0, state, [], timeout_ms, n)
  }
  finish(rep, state, list.reverse(outcomes), now_microseconds() - started)
}

@target(erlang)
fn workers(parallel: config.Parallelism) -> Int {
  case parallel {
    config.Sequential -> 1
    config.Workers(n) -> n
    config.AutoParallel -> schedulers_online()
  }
}

@target(erlang)
fn run_sequential(
  rep: Reporter(s),
  state: s,
  tests: List(#(String, String)),
  timeout_ms: Int,
) -> #(s, List(TestOutcome)) {
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
}

@target(erlang)
/// A sliding window over the test list: admit tests (oldest slot first)
/// until `workers` are in flight, then await the oldest before admitting
/// more. Results are reported in discovery order — identical to the
/// sequential stream — while execution overlaps. Awaiting the oldest
/// means a slow head lets the rest of the window drain without refilling,
/// which trades a little throughput for deterministic reporting.
fn run_window(
  rep: Reporter(s),
  pending: List(#(String, String)),
  running: List(#(String, String, TestHandle)),
  running_count: Int,
  state: s,
  outcomes: List(TestOutcome),
  timeout_ms: Int,
  workers: Int,
) -> #(s, List(TestOutcome)) {
  case pending {
    [next, ..rest] if running_count < workers -> {
      let #(module, function) = next
      let state = rep.handle(state, event.TestStart(module, function))
      let handle = start_test(module, function, timeout_ms)
      run_window(
        rep,
        rest,
        list.append(running, [#(module, function, handle)]),
        running_count + 1,
        state,
        outcomes,
        timeout_ms,
        workers,
      )
    }
    _ ->
      case running {
        [] -> #(state, outcomes)
        [#(module, function, handle), ..running_rest] -> {
          let #(invocation, duration) = await_test(handle)
          let out = outcome.classify(module, function, invocation)
          let state =
            rep.handle(state, event.TestResult(module, function, out, duration))
          run_window(
            rep,
            pending,
            running_rest,
            running_count - 1,
            state,
            [out, ..outcomes],
            timeout_ms,
            workers,
          )
        }
      }
  }
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

@target(erlang)
/// Run one exported zero-arity function in its own monitored process with a
/// timeout. Public so vouch's own suite can exercise isolation directly.
@external(erlang, "vouch_ffi", "run_test")
pub fn run_in_process(
  module: String,
  function: String,
  timeout_ms: Int,
) -> outcome.Invocation

/// An in-flight test started by `start_test`: created and consumed only by
/// the FFI.
pub type TestHandle

@target(erlang)
/// Start one test without waiting for it. The spawned middleman runs the
/// same run_test as the sequential path — identical isolation and timeout
/// semantics — and `await_test` collects the invocation and its duration
/// in microseconds. Public so the suite can prove concurrency directly.
@external(erlang, "vouch_ffi", "start_test")
pub fn start_test(
  module: String,
  function: String,
  timeout_ms: Int,
) -> TestHandle

@target(erlang)
@external(erlang, "vouch_ffi", "await_test")
pub fn await_test(handle: TestHandle) -> #(outcome.Invocation, Int)

@target(erlang)
@external(erlang, "vouch_ffi", "schedulers_online")
fn schedulers_online() -> Int

// On the JavaScript target dynamic import and test invocation are async, so
// sequencing lives in the FFI, which threads reporter state through Gleam
// callbacks. The state tuple is (reporter state, outcomes so far, start time
// of the test in flight).

// JavaScript has no cheap process primitive: tests run in-process and the
// timeout does not apply. A documented target difference — but asking for a
// non-default timeout here deserves a loud note rather than silence.
@target(javascript)
pub fn run(
  rep: Reporter(s),
  filter: Option(String),
  timeout_ms: Int,
  parallel: config.Parallelism,
) -> Nil {
  case timeout_ms == config.default_timeout_ms {
    True -> Nil
    False ->
      io.println_error(
        "vouch: --timeout has no effect on the JavaScript target — tests run in-process and cannot be interrupted",
      )
  }
  case parallel {
    config.Sequential -> Nil
    _ ->
      io.println_error(
        "vouch: --parallel has no effect on the JavaScript target — tests run in-process on a single thread",
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
      let st = rep.handle(st, event.TestResult(module, function, out, duration))
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
  on_test_result: fn(
    #(s, List(TestOutcome), Int),
    String,
    String,
    Result(Nil, Dynamic),
  ) -> #(s, List(TestOutcome), Int),
  on_done: fn(#(s, List(TestOutcome), Int)) -> Nil,
) -> Nil
