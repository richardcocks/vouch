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

// Erlang-only fixtures for process-isolation tests. Invoked by name via
// runner.run_in_process, never discovered (no _test suffix).

@target(erlang)
pub fn sleeps_forever() -> Nil {
  sleep(60_000)
}

// Long enough that two sequential runs are clearly distinguishable from
// two overlapping ones, short enough not to drag the suite.
@target(erlang)
pub fn sleeps_briefly() -> Nil {
  sleep(300)
}

@target(erlang)
pub fn crashes_linked() -> Nil {
  spawn_link(fn() { panic as "crash in linked process" })
  // Stay alive long enough to receive the exit signal.
  sleep(1000)
}

@target(erlang)
@external(erlang, "timer", "sleep")
fn sleep(ms: Int) -> Nil

// The pid is discarded, so the dishonest Nil return type is harmless here.
@target(erlang)
@external(erlang, "erlang", "spawn_link")
fn spawn_link(f: fn() -> Nil) -> Nil
