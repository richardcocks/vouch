//// vouch's own test suite. During the walking-skeleton phase this doubles as
//// a payload probe: one test per failure shape, so running it shows the raw
//// panic payload for each on both targets. The deliberately failing tests
//// will be replaced with assertions *about* those payloads once decoding
//// exists.

import helpers
import vouch

pub fn main() -> Nil {
  vouch.main()
}

pub fn passing_test() {
  assert 1 + 1 == 2
}

pub fn assert_binop_test() {
  assert 1 + 1 == 3
}

pub fn assert_call_test() {
  assert helpers.is_even(3)
}

pub fn let_assert_test() {
  let assert Ok(_) = helpers.failing_result()
}

pub fn panic_test() {
  panic as "explicit panic message"
}

pub fn todo_body_test() {
  todo as "test not written yet"
}

pub fn todo_deep_test() {
  helpers.unimplemented()
}
