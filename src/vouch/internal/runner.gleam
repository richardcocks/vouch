//// Orchestration: discovery, execution, event emission, exit codes. The
//// per-target loops live here with the narrow FFI contract at the bottom.

import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option}
import gleam/order
import gleam/string
import vouch/internal/config
import vouch/internal/event.{type Tally, Tally}
import vouch/internal/outcome.{type TestOutcome}
import vouch/internal/reporter.{type Reporter}
import vouch/internal/term

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
  show_crash_reports: Bool,
) -> Nil {
  let t = tally(outcomes)
  let _ = rep.handle(state, event.RunEnd(t, duration))
  let unattributed = unattributed_crash_reports()
  print_unattributed(unattributed)
  case show_crash_reports {
    True -> print_crash_reports(all_crash_reports())
    False -> Nil
  }
  case unattributed {
    [] -> halt(exit_code(t))
    // A crash no outcome accounts for must not hide behind a green run.
    _ -> halt(1)
  }
}

/// Crash reports no test claimed: the process died after its test had
/// finished (named here, from the group leader it inherited), or outside
/// any test. Printed on stderr — clear of a machine-read stdout stream —
/// and the run fails.
fn print_unattributed(
  reports: List(#(String, Option(#(String, String)))),
) -> Nil {
  case reports {
    [] -> Nil
    _ -> {
      term.warn(
        count(reports, "crash report")
        <> " not charged to any test — the run fails:",
      )
      list.each(reports, fn(report) {
        let #(text, owner) = report
        case owner {
          option.Some(#(module, function)) ->
            io.print_error(
              "vouch: from a process started by "
              <> module
              <> "."
              <> function
              <> ", which died after the test finished:\n",
            )
          option.None ->
            io.print_error("vouch: from a process no test started:\n")
        }
        io.print_error(text)
      })
    }
  }
}

/// `--show-crash-reports`: every BEAM crash report captured during the run,
/// attributed or not, reprinted in full as one block after the summary on
/// stderr — the raw report behind a "Background process crashed" failure.
fn print_crash_reports(reports: List(String)) -> Nil {
  case reports {
    [] -> Nil
    _ -> {
      term.warn(count(reports, "crash report") <> " captured during the run:")
      list.each(reports, io.print_error)
    }
  }
}

fn count(items: List(a), noun: String) -> String {
  case items {
    [_] -> "1 " <> noun
    _ -> int.to_string(list.length(items)) <> " " <> noun <> "s"
  }
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

/// The target this build is running on. Per-target behaviour is chosen at
/// runtime rather than with `@target` conditional compilation, so every
/// function here compiles for both targets and the API is identical
/// everywhere; the never-taken side of each split is an FFI stub. Dispatch
/// sites match exhaustively, so a future target variant would surface
/// every decision point as a compile error.
pub type Target {
  Erlang
  JavaScript
}

pub fn target() -> Target {
  case is_erlang() {
    True -> Erlang
    False -> JavaScript
  }
}

// A Bool keeps the FFI contract trivial: constructing Target records from
// the FFI would couple it to compiler-generated code. If a third target is
// ever added it needs its own FFI file anyway; this gets replaced then.
@external(erlang, "vouch_ffi", "is_erlang")
@external(javascript, "../../vouch_ffi.mjs", "is_erlang")
fn is_erlang() -> Bool

pub fn run(
  rep: Reporter(s),
  filter: Option(String),
  timeout_ms: Int,
  parallel: config.Parallelism,
  show_crash_reports: Bool,
) -> Nil {
  case target() {
    Erlang -> run_beam(rep, filter, timeout_ms, parallel, show_crash_reports)
    JavaScript -> run_js(rep, filter, timeout_ms, parallel, show_crash_reports)
  }
}

// On the Erlang target enumeration and invocation are synchronous, so the
// whole loop is Gleam.

fn run_beam(
  rep: Reporter(s),
  filter: Option(String),
  timeout_ms: Int,
  parallel: config.Parallelism,
  show_crash_reports: Bool,
) -> Nil {
  capture_diagnostics()
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
  finish(
    rep,
    state,
    list.reverse(outcomes),
    now_microseconds() - started,
    show_crash_reports,
  )
}

fn workers(parallel: config.Parallelism) -> Int {
  case parallel {
    config.Sequential -> 1
    config.Workers(n) -> n
    config.AutoParallel -> schedulers_online()
  }
}

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
    let #(invocation, reports) = run_in_process(module, function, timeout_ms)
    let duration = now_microseconds() - test_started
    let out =
      outcome.classify(module, function, invocation)
      |> outcome.with_crash_reports(module, function, reports)
    let state =
      rep.handle(state, event.TestResult(module, function, out, duration))
    #(state, [out, ..outcomes])
  })
}

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
          let #(invocation, reports, duration) = await_test(handle)
          let out =
            outcome.classify(module, function, invocation)
            |> outcome.with_crash_reports(module, function, reports)
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

/// Divert BEAM crash reports from the default logger handler into a table
/// the runner reads after each test (see vouch_ffi.erl). Installed once per
/// run, before any test starts.
@external(erlang, "vouch_ffi", "capture_diagnostics")
@external(javascript, "../../vouch_ffi.mjs", "capture_diagnostics")
fn capture_diagnostics() -> Nil

/// The text of every captured crash report, in arrival order.
@external(erlang, "vouch_ffi", "all_diagnostics")
@external(javascript, "../../vouch_ffi.mjs", "all_diagnostics")
fn all_crash_reports() -> List(String)

/// The captured crash reports no test claimed, each with the test whose
/// process tree the dying process belonged to, when it was one.
@external(erlang, "vouch_ffi", "unattributed_diagnostics")
@external(javascript, "../../vouch_ffi.mjs", "unattributed_diagnostics")
fn unattributed_crash_reports() -> List(#(String, Option(#(String, String))))

/// Remove and return the captured crash reports whose text contains
/// `marker`, leaving the rest alone. Public so vouch's own suite can crash a
/// process in its own process tree on purpose, consume the report (so the
/// test is not charged with it) and assert it was captured rather than
/// printed, without touching reports that belong to other tests.
@external(erlang, "vouch_ffi", "take_diagnostics_matching")
@external(javascript, "../../vouch_ffi.mjs", "take_diagnostics_matching")
pub fn take_diagnostics_matching(marker: String) -> List(String)

/// Remove and return the rendered reasons of unattributed crashes (a worker
/// that outlived its test) whose text contains `marker`. Public so vouch's
/// own suite can prove the late-crash path reaches the unattributed table,
/// consuming its deliberately-caused entry so the suite run stays green.
@external(erlang, "vouch_ffi", "take_unattributed_matching")
@external(javascript, "../../vouch_ffi.mjs", "take_unattributed_matching")
pub fn take_unattributed_matching(marker: String) -> List(String)

fn path_to_module(path: String) -> String {
  path
  |> string.replace("\\", "/")
  |> string.replace(".gleam", "")
}

@external(erlang, "vouch_ffi", "find_test_files")
@external(javascript, "../../vouch_ffi.mjs", "find_test_files")
fn find_test_files() -> List(String)

@external(erlang, "vouch_ffi", "exported_zero_arity")
@external(javascript, "../../vouch_ffi.mjs", "exported_zero_arity")
fn exported_zero_arity(module: String) -> List(String)

/// Run one exported zero-arity function in its own monitored process with a
/// timeout, and collect the crash reports of processes it started that died
/// while it ran. Public so vouch's own suite can exercise isolation
/// directly.
@external(erlang, "vouch_ffi", "run_test")
@external(javascript, "../../vouch_ffi.mjs", "run_test")
pub fn run_in_process(
  module: String,
  function: String,
  timeout_ms: Int,
) -> #(outcome.Invocation, List(outcome.CrashReport))

/// An in-flight test started by `start_test`: created and consumed only by
/// the FFI.
pub type TestHandle

/// Start one test without waiting for it. The spawned middleman runs the
/// same run_test as the sequential path — identical isolation, timeout and
/// crash-report semantics — and `await_test` collects the invocation, the
/// crash reports charged to the test, and its duration in microseconds.
/// Public so the suite can prove concurrency directly.
@external(erlang, "vouch_ffi", "start_test")
@external(javascript, "../../vouch_ffi.mjs", "start_test")
pub fn start_test(
  module: String,
  function: String,
  timeout_ms: Int,
) -> TestHandle

@external(erlang, "vouch_ffi", "await_test")
@external(javascript, "../../vouch_ffi.mjs", "await_test")
pub fn await_test(
  handle: TestHandle,
) -> #(outcome.Invocation, List(outcome.CrashReport), Int)

@external(erlang, "vouch_ffi", "schedulers_online")
@external(javascript, "../../vouch_ffi.mjs", "schedulers_online")
fn schedulers_online() -> Int

// On the JavaScript target dynamic import and test invocation are async, so
// sequencing lives in the FFI, which threads reporter state through Gleam
// callbacks. The state tuple is (reporter state, outcomes so far, start time
// of the test in flight).

/// JavaScript has no cheap process primitive: tests run in-process, so
/// `--timeout` and `--parallel` do not apply there, and with no BEAM there
/// are no crash reports for `--show-crash-reports` to show. A documented
/// target difference — but a flag that will be ignored deserves a loud
/// note rather than silence.
pub fn warn_ineffective_js_flags(
  timeout_ms: Int,
  parallel: config.Parallelism,
  show_crash_reports: Bool,
) -> Nil {
  case show_crash_reports {
    False -> Nil
    True ->
      term.warn(
        "--show-crash-reports has no effect on the JavaScript target — there is no BEAM to report crashes",
      )
  }
  case timeout_ms == config.default_timeout_ms {
    True -> Nil
    False ->
      term.warn(
        "--timeout has no effect on the JavaScript target — tests run in-process and cannot be interrupted",
      )
  }
  case parallel {
    config.Sequential -> Nil
    _ ->
      term.warn(
        "--parallel has no effect on the JavaScript target — tests run in-process on a single thread",
      )
  }
}

fn run_js(
  rep: Reporter(s),
  filter: Option(String),
  timeout_ms: Int,
  parallel: config.Parallelism,
  show_crash_reports: Bool,
) -> Nil {
  warn_ineffective_js_flags(timeout_ms, parallel, show_crash_reports)
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
      finish(
        rep,
        st,
        list.reverse(outs),
        now_microseconds() - started,
        show_crash_reports,
      )
    },
  )
}

@external(erlang, "vouch_ffi", "run_tests")
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
