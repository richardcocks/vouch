//// One test per outcome flavour, so a plain run shows vouch's full range:
////
////   gleam test                        - 3 pass, 5 fail, 2 todo, 1 skip
////                                       (JavaScript: 4 pass, 4 fail — no
////                                       process crashes behind
////                                       background_job_test there)
////   gleam test -- --timeout=100       - slow_test also fails as a timeout
////   gleam test -- --filter=slow       - just the slow test
////   gleam test -- --format=json       - the same as a JSONL stream
////   gleam test -- --junit=report.xml  - plus a CI-ready XML report
////   gleam test -- --show-crash-reports
////                                     - plus the full BEAM crash report
////                                       from background_job_test's worker
////   gleam test -- --keep-leaked-processes
////                                     - leave leaky_worker_test's worker
////                                       running instead of killing it

import playground
import vouch

pub fn main() -> Nil {
  vouch.main()
}

pub fn fast_pass_test() {
  assert playground.add(1, 2) == 3
}

/// The test body passes — but the unlinked worker it starts crashes behind
/// its back, and nothing is linked to or monitoring it. The BEAM's crash
/// report is the only trace; vouch charges it to this test, which fails as
/// "Background process crashed". `--show-crash-reports` prints the raw
/// report too. (On JavaScript there is no worker, so this passes.)
pub fn background_job_test() {
  playground.start_background_job()
  // Give the job a moment, as a test of fire-and-forget code typically
  // does; it also makes the worker's death land before the test ends, so
  // the outcome is the same on a one-scheduler CI box.
  playground.sleep(20)
  assert playground.add(0, 0) == 0
}

/// Starts a worker and returns while it is still running. The test passes —
/// leaking a process is not a failure — but on the BEAM vouch kills the
/// worker at the end of this test and lists it after the summary, so it
/// cannot pollute a later test. (On JavaScript there is no worker at all.)
pub fn leaky_worker_test() {
  playground.start_long_worker()
  assert playground.add(2, 2) == 4
}

/// Passes with the default 5000ms timeout; fails with --timeout=100.
pub fn slow_test() {
  playground.sleep(300)
  assert playground.add(2, 2) == 4
}

/// A wrong assertion: renders left/right/operator detail.
pub fn failing_assert_test() {
  assert playground.add(2, 2) == 5
}

/// A wrong predicate: renders the call as written, and the value behind
/// each argument that was not written out literally.
pub fn failing_predicate_test() {
  let spend = 250
  assert playground.within_budget(spend)
}

/// A crash that is not a Gleam panic: the code under test calls into a
/// missing module — the stale-.beam problem. The report names what was
/// being called ("Crashed: Undef calling config_parser:parse/1") instead of
/// an information-free "Crashed: Undef".
pub fn crashing_config_test() {
  playground.parse_config("gleam.toml")
}

/// A failing pattern match: renders the unmatched value.
pub fn failing_let_assert_test() {
  let assert Ok(n) = Error("the port was closed")
  n
}

/// Exercises unimplemented code: a Todo outcome, grouped by site.
pub fn rate_limit_allows_test() {
  assert playground.rate_limit(1)
}

/// Another test blocked on the same todo site: the summary groups them.
pub fn rate_limit_blocks_test() {
  assert playground.rate_limit(1000) == False
}

/// A pending test body: a Skipped outcome.
pub fn rate_limit_resets_test() {
  todo as "write this once rate_limit exists"
}
