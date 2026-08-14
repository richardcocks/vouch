//// Not a *_test module, so vouch must not treat it as one. These functions
//// stand in for "code under test": the suite invokes them via catch_panic
//// and asserts on the decoded payloads.

pub fn is_even(n: Int) -> Bool {
  n % 2 == 0
}

pub fn failing_result() -> Result(Nil, String) {
  Error("nope")
}

pub fn panics() -> Nil {
  panic as "helper panicked"
}

pub fn assert_fails() -> Nil {
  assert 1 + 1 == 3
}

pub fn assert_call_fails() -> Nil {
  assert is_even(3)
}

pub fn let_assert_fails() -> Nil {
  let assert Ok(_) = failing_result()
  Nil
}

pub fn unimplemented() -> Nil {
  todo as "unimplemented function in code under test"
}
