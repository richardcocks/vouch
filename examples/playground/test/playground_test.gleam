//// One test per outcome flavour, so a plain run shows vouch's full range:
////
////   gleam test                        - 2 pass, 4 fail, 2 todo, 1 skip
////   gleam test -- --timeout=100       - slow_test also fails as a timeout
////   gleam test -- --filter=slow       - just the slow test
////   gleam test -- --format=json       - the same as a JSONL stream
////   gleam test -- --junit=report.xml  - plus a CI-ready XML report

import playground
import vouch

pub fn main() -> Nil {
  vouch.main()
}

pub fn fast_pass_test() {
  assert playground.add(1, 2) == 3
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
