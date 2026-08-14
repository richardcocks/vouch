//// Classifies a raw test result into vouch's outcome model.
////
//// The todo rule: if a `todo` panic's site is the running test function
//// itself, the test is a pending stub (Skipped). A `todo` anywhere else
//// means the test exercised unimplemented code (Todo) — still not-done, so
//// it fails the run, but reported distinctly from a broken test.

import gleam/dynamic.{type Dynamic}
import vouch/internal/gleam_panic.{type GleamPanic}

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
}

pub fn classify(
  test_module: String,
  test_function: String,
  result: Result(Nil, Dynamic),
) -> TestOutcome {
  case result {
    Ok(Nil) -> Pass
    Error(raw) ->
      case gleam_panic.from_dynamic(raw) {
        Ok(p) -> classify_panic(test_module, test_function, p)
        Error(Nil) -> Failed(UnknownDetail(raw))
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
