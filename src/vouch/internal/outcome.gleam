//// Classifies a test invocation into vouch's outcome model.
////
//// The todo rule: if a `todo` panic's site is the running test function
//// itself, the test is a pending stub (Skipped). A `todo` anywhere else
//// means the test exercised unimplemented code (Todo) — still not-done, so
//// it fails the run, but reported distinctly from a broken test.

import gleam/dynamic.{type Dynamic}
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
