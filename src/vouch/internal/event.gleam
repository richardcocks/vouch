//// The event stream every reporter consumes. Document formats (JUnit XML)
//// are folds that buffer until RunEnd; streaming formats (console, JSONL)
//// print as events arrive.

import vouch/internal/outcome.{type TestOutcome}

pub type Event {
  RunStart(total: Int)
  TestStart(module: String, function: String)
  TestResult(
    module: String,
    function: String,
    outcome: TestOutcome,
    duration_microseconds: Int,
  )
  RunEnd(tally: Tally, duration_microseconds: Int)
}

pub type Tally {
  Tally(passed: Int, failed: Int, todos: Int, skipped: Int)
}
