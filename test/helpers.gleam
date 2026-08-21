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

/// An argument that is a name rather than a literal: the report has to show
/// both what the call site wrote and what it evaluated to.
pub fn assert_call_with_binding_fails() -> Nil {
  let n = 3
  assert is_even(n)
}

/// An asserted expression that is neither a comparison nor a call.
pub fn assert_expression_fails() -> Nil {
  let ready = False
  assert ready
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
/// Stands in for a call into a stale or missing .beam: the module does not
/// exist, so the call raises undef — no Gleam payload, only a stacktrace
/// whose top frame names the M:F/A that was called.
@external(erlang, "vouch_no_such_module", "boom")
pub fn calls_missing_function() -> Nil

@target(erlang)
/// The same undef, but in a linked process: the test process is killed by
/// the exit signal, whose reason still carries the stacktrace.
pub fn crashes_linked_undef() -> Nil {
  spawn_link(fn() { calls_missing_function() })
  // Stay alive long enough to receive the exit signal.
  sleep(1000)
}

@target(erlang)
/// A fire-and-forget worker that panics: unlinked, unmonitored by the
/// caller, so nothing but the BEAM's crash report records the death. The
/// caller waits for the worker to be gone before returning, so the report
/// is always in flight by the time the test's result reaches the runner.
pub fn crashes_in_background() -> Nil {
  run_in_background(fn() { panic as "crash in background process" })
}

@target(erlang)
/// The same, but the worker hits unimplemented code: the crash report
/// carries a todo, which must classify as a Todo outcome, not a failure.
pub fn todo_in_background() -> Nil {
  run_in_background(unimplemented)
}

@target(erlang)
/// The same, but a raw non-Gleam error: an undef with no Gleam payload.
pub fn undef_in_background() -> Nil {
  run_in_background(calls_missing_function)
}

@target(erlang)
/// A fire-and-forget worker that is still alive when the caller returns and
/// crashes shortly after: its death can never be charged to the test that
/// started it, so the runner's tracer records it as unattributed.
pub fn returns_before_worker_crashes() -> Nil {
  spawn(fn() {
    sleep(30)
    panic as "late crash in background process"
  })
}

@target(erlang)
@external(erlang, "timer", "sleep")
fn sleep(ms: Int) -> Nil

@target(erlang)
@external(erlang, "vouch_helpers_ffi", "run_in_background")
fn run_in_background(f: fn() -> Nil) -> Nil

@target(erlang)
@external(erlang, "erlang", "spawn")
fn spawn(f: fn() -> Nil) -> Nil

// The pid is discarded, so the dishonest Nil return type is harmless here.
@target(erlang)
@external(erlang, "erlang", "spawn_link")
fn spawn_link(f: fn() -> Nil) -> Nil
