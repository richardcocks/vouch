//// Code under test for the playground: one implemented function, one
//// unimplemented one (the target for deep-todo outcomes).

pub fn add(a: Int, b: Int) -> Int {
  a + b
}

pub fn within_budget(spend: Int) -> Bool {
  spend <= 100
}

pub fn rate_limit(_requests: Int) -> Bool {
  todo as "rate limiting is not implemented yet"
}

@external(erlang, "playground_ffi", "sleep")
@external(javascript, "./playground_ffi.mjs", "sleep")
pub fn sleep(ms: Int) -> Nil

/// A fire-and-forget worker with a bug: the caller gets Nil back and
/// carries on, while the unlinked process it started dies. The test that
/// calls this passes — the crash is only visible through the BEAM's crash
/// report, which vouch swallows unless `--show-crash-reports` is given.
pub fn start_background_job() -> Nil {
  spawn(fn() { panic as "background job crashed: queue is full" })
}

@external(erlang, "playground_ffi", "spawn")
@external(javascript, "./playground_ffi.mjs", "spawn")
fn spawn(job: fn() -> Nil) -> Nil

/// Stands in for a dependency whose .beam has gone stale or missing: no
/// config_parser module exists, so on the BEAM the call raises undef and
/// the report names config_parser:parse/1 from the stacktrace. On
/// JavaScript the FFI throws a plain TypeError instead — a raw crash with
/// no site, which is all a JS stacktrace offers.
@external(erlang, "config_parser", "parse")
@external(javascript, "./playground_ffi.mjs", "parse")
pub fn parse_config(path: String) -> String
