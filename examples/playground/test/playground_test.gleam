//// One test per outcome flavour, so a plain run shows vouch's full range:
////
////   gleam test                        - 3 pass, 2 fail, 1 todo, 1 skip
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
