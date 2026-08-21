//// Classifies a test invocation into vouch's outcome model.
////
//// The todo rule: if a `todo` panic's site is the running test function
//// itself, the test is a pending stub (Skipped). A `todo` anywhere else
//// means the test exercised unimplemented code (Todo) — still not-done, so
//// it fails the run, but reported distinctly from a broken test.

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option}
import vouch/internal/gleam_panic.{type GleamPanic}

/// How a test invocation ended. On the Erlang target tests run in their own
/// monitored process: a panic is caught inside that process and sent back
/// (Panicked), a process killed by an exit signal arrives as Died, and a
/// test that outlives its timeout is killed and arrives as TimedOut.
pub type Invocation {
  Passed
  Panicked(Dynamic)
  TimedOut(after_ms: Int)
  Died(Dynamic)
}

pub type TestOutcome {
  Pass
  /// The test body itself is a `todo`: a pending test, not a failure.
  Skipped(GleamPanic)
  /// The test hit unimplemented (`todo`) code outside its own body.
  Todo(GleamPanic)
  Failed(detail: FailureDetail)
}

pub type FailureDetail {
  PanicDetail(GleamPanic)
  /// Not a Gleam panic: a raw runtime error from FFI or similar. The raw
  /// value is the reason alone — the stacktrace behind it is reduced to
  /// `site`, so inspecting the reason never dumps frames.
  UnknownDetail(raw: Dynamic, site: Option(CrashSite))
  /// The test ran longer than the per-test timeout and was killed.
  TimeoutDetail(after_ms: Int)
  /// The test process died without reporting: an exit signal it did not
  /// cause by panicking, e.g. an explicit exit.
  ExitDetail(raw: Dynamic, site: Option(CrashSite))
  /// A process the test started died while the test ran, without taking
  /// the test down with it — an unlinked worker, a fire-and-forget job.
  /// The test itself may have passed; the BEAM's crash report for the
  /// death was captured and charged to the test (Erlang target only).
  /// `cause` is what killed the process: a `PanicDetail` for a Gleam
  /// panic or failed assertion, an `UnknownDetail` for anything else.
  BackgroundCrashDetail(cause: FailureDetail)
}

/// A process that crashed while a test ran, as seen by the runner's tracer:
/// the exit reason of the dead process (a Gleam panic map for a panic,
/// assert or todo; a raw `{Reason, Stacktrace}` otherwise), which decodes
/// exactly like a caught panic.
pub type CrashReport {
  CrashReport(reason: Dynamic)
}

/// The top frame of the stacktrace behind a non-Gleam crash: what was being
/// called when the test died. An undef from a stale .beam carries no Gleam
/// payload at all, so this frame is the only thing that names the failure.
pub type CrashSite {
  CrashSite(
    module: String,
    function: String,
    arity: Int,
    /// The frame's file and line, when the BEAM recorded them. An undef
    /// frame has neither: the called function does not exist.
    location: Option(#(String, Int)),
  )
}

/// Split a raw caught term into the error reason and the crash site from the
/// top of its stacktrace, for terms shaped {Reason, Stacktrace} — the shape
/// catch_panic captures and BEAM exit reasons already have. Terms with no
/// recognisable stacktrace pass through unchanged with no site; on
/// JavaScript the stack is an unparsed string, so there is never a site.
@external(erlang, "vouch_ffi", "split_crash")
@external(javascript, "../../vouch_ffi.mjs", "split_crash")
fn split_crash(raw: Dynamic) -> #(Dynamic, Option(CrashSite))

/// Wrap a directly-caught result (catch_panic, or the JavaScript run loop's
/// try/catch) as an invocation.
pub fn from_caught(result: Result(Nil, Dynamic)) -> Invocation {
  case result {
    Ok(Nil) -> Passed
    Error(raw) -> Panicked(raw)
  }
}

pub fn classify(
  test_module: String,
  test_function: String,
  invocation: Invocation,
) -> TestOutcome {
  case invocation {
    Passed -> Pass
    Panicked(raw) ->
      case gleam_panic.from_dynamic(raw) {
        Ok(p) -> classify_panic(test_module, test_function, p)
        Error(Nil) -> {
          let #(reason, site) = split_crash(raw)
          Failed(UnknownDetail(reason, site))
        }
      }
    TimedOut(ms) -> Failed(TimeoutDetail(ms))
    // A linked process that panicked kills the test process with the panic
    // as the exit reason, so try decoding it before giving up.
    Died(raw) ->
      case gleam_panic.from_dynamic(raw) {
        Ok(p) -> classify_panic(test_module, test_function, p)
        Error(Nil) -> {
          let #(reason, site) = split_crash(raw)
          Failed(ExitDetail(reason, site))
        }
      }
  }
}

pub fn classify_panic(
  test_module: String,
  test_function: String,
  p: GleamPanic,
) -> TestOutcome {
  case p.kind {
    gleam_panic.Todo ->
      case p.module == test_module && p.function == test_function {
        True -> Skipped(p)
        False -> Todo(p)
      }
    _ -> Failed(PanicDetail(p))
  }
}

/// Fold the crash reports charged to a test into its outcome. A process
/// the test started and died behind its back is a failure of the test —
/// or a Todo, when what killed the process was unimplemented code, by the
/// same rule as a todo the test reached directly. The more severe verdict
/// wins (Failed over Todo over Skipped over Pass), the test's own on a tie:
/// a test that failed on its own keeps its own failure, and the reports
/// stay available to `--show-crash-reports`.
pub fn with_crash_reports(
  own: TestOutcome,
  test_module: String,
  test_function: String,
  reports: List(CrashReport),
) -> TestOutcome {
  list.fold(reports, own, fn(worst, report) {
    let crash = classify_report(test_module, test_function, report)
    case severity(crash) > severity(worst) {
      True -> crash
      False -> worst
    }
  })
}

fn classify_report(
  test_module: String,
  test_function: String,
  report: CrashReport,
) -> TestOutcome {
  case gleam_panic.from_dynamic(report.reason) {
    Ok(p) ->
      case classify_panic(test_module, test_function, p) {
        Failed(cause) -> Failed(BackgroundCrashDetail(cause))
        todo_or_skipped -> todo_or_skipped
      }
    Error(Nil) -> {
      let #(reason, site) = split_crash(report.reason)
      Failed(BackgroundCrashDetail(UnknownDetail(reason, site)))
    }
  }
}

fn severity(out: TestOutcome) -> Int {
  case out {
    Pass -> 0
    Skipped(_) -> 1
    Todo(_) -> 2
    Failed(_) -> 3
  }
}
