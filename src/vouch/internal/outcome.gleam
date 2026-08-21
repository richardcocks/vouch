//// Classifies a test invocation into vouch's outcome model.
////
//// The todo rule: if a `todo` panic's site is the running test function
//// itself, the test is a pending stub (Skipped). A `todo` anywhere else
//// means the test exercised unimplemented code (Todo) — still not-done, so
//// it fails the run, but reported distinctly from a broken test.

import gleam/dynamic.{type Dynamic}
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
  /// Not a Gleam panic: a raw runtime error from FFI or similar.
  UnknownDetail(raw: Dynamic)
  /// The test ran longer than the per-test timeout and was killed.
  TimeoutDetail(after_ms: Int)
  /// The test process died without reporting: an exit signal it did not
  /// cause by panicking, e.g. an explicit exit.
  ExitDetail(raw: Dynamic)
}

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
        Error(Nil) -> Failed(UnknownDetail(raw))
      }
    TimedOut(ms) -> Failed(TimeoutDetail(ms))
    // A linked process that panicked kills the test process with the panic
    // as the exit reason, so try decoding it before giving up.
    Died(raw) ->
      case gleam_panic.from_dynamic(raw) {
        Ok(p) -> classify_panic(test_module, test_function, p)
        Error(Nil) -> Failed(ExitDetail(raw))
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
