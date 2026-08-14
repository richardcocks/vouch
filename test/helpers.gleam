//// Not a *_test module, so vouch must not treat it as one. Stands in for
//// "code under test" so the suite can probe a todo raised outside the test
//// function itself (the Todo outcome, as opposed to Skipped).

pub fn is_even(n: Int) -> Bool {
  n % 2 == 0
}

pub fn failing_result() -> Result(Nil, String) {
  Error("nope")
}

pub fn unimplemented() -> Nil {
  todo as "unimplemented function in code under test"
}
