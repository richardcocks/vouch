//// End-to-end tests: run `gleam test` in examples/playground as a
//// subprocess and assert on the JSONL stream and exit code. This is where
//// the deliberately-red outcomes (Fail, Todo, timeouts) get automated
//// coverage that vouch's own green suite cannot host.
////
//// Erlang-target only: one subprocess implementation is enough, and the
//// inner runs cover both targets. These are the slowest tests in the suite
//// (each spawns a full `gleam test`, including the playground's compile
//// check).

import gleam/list
import gleam/string

@target(erlang)
pub fn playground_erlang_e2e_test() {
  let assert Ok(#(code, out)) =
    run_command("gleam", ["test", "--", "--format=json"], "examples/playground")
  assert code == 1
  assert string.contains(
    out,
    "\"event\":\"run_end\",\"passed\":2,\"failed\":5,\"todo\":2,\"skipped\":1",
  )
  assert string.contains(out, "\"outcome\":\"todo\"")
  assert string.contains(out, "\"site_function\":\"rate_limit\"")
  // background_job_test's worker crash is charged to the test and streamed
  // as a failure with the cause nested.
  assert string.contains(
    out,
    "\"function\":\"background_job_test\",\"outcome\":\"fail\"",
  )
  assert string.contains(
    out,
    "\"kind\":\"background_crash\",\"cause\":{\"message\":\"background job crashed: queue is full\"",
  )
  // The undef crash carries its call site through the whole pipeline:
  // subprocess, stream, JSON encoding.
  assert string.contains(out, "\"kind\":\"unknown\"")
  assert string.contains(
    out,
    "\"site_module\":\"config_parser\",\"site_function\":\"parse\",\"site_arity\":1",
  )
  // Every stdout line must be a JSON object: the stream stays machine-clean.
  // Asserting that no offending line was found (rather than a Bool over the
  // whole list) makes a failure print the first non-JSON line itself.
  let offending =
    out
    |> string.trim
    |> string.split("\n")
    |> list.find(fn(line) {
      !{ string.starts_with(line, "{") && string.ends_with(line, "}") }
    })
  assert offending == Error(Nil)
}

@target(erlang)
pub fn playground_javascript_e2e_test() {
  let assert Ok(#(code, out)) =
    run_command(
      "gleam",
      ["test", "--target", "javascript", "--", "--format=json"],
      "examples/playground",
    )
  assert code == 1
  // One more pass than on Erlang: JavaScript has no process to crash
  // behind background_job_test.
  assert string.contains(
    out,
    "\"event\":\"run_end\",\"passed\":3,\"failed\":4,\"todo\":2,\"skipped\":1",
  )
  // On JavaScript the crash is a raw TypeError with no site to extract.
  assert string.contains(out, "\"kind\":\"unknown\"")
}

@target(erlang)
pub fn playground_timeout_e2e_test() {
  let assert Ok(#(code, out)) =
    run_command(
      "gleam",
      ["test", "--", "--format=json", "--timeout=100"],
      "examples/playground",
    )
  assert code == 1
  assert string.contains(out, "\"kind\":\"timeout\"")
  assert string.contains(out, "\"timeout_ms\":100")
  assert string.contains(
    out,
    "\"event\":\"run_end\",\"passed\":1,\"failed\":6,\"todo\":2,\"skipped\":1",
  )
}

@target(erlang)
/// A parallel run must classify identically to the sequential runs above:
/// same outcome counts, same exit code, results still present per test.
pub fn playground_parallel_e2e_test() {
  let assert Ok(#(code, out)) =
    run_command(
      "gleam",
      ["test", "--", "--format=json", "--parallel"],
      "examples/playground",
    )
  assert code == 1
  assert string.contains(
    out,
    "\"event\":\"run_end\",\"passed\":2,\"failed\":5,\"todo\":2,\"skipped\":1",
  )
  assert string.contains(out, "\"site_function\":\"rate_limit\"")
  // Attribution holds under --parallel too: the worker's crash is charged
  // to background_job_test, not to whichever test happened to be in flight.
  assert string.contains(
    out,
    "\"function\":\"background_job_test\",\"outcome\":\"fail\"",
  )
}

@target(erlang)
/// background_job_test's body passes while the unlinked worker it starts
/// crashes. The crash must fail the test, named in the console report; the
/// BEAM's raw crash report must stay out of a default run and come back —
/// after the summary — with --show-crash-reports. stderr is merged into the
/// captured stream here because that is where the raw reports go; the
/// stdout-only harness above proves they never reach stdout.
pub fn playground_crash_reports_e2e_test() {
  let assert Ok(#(_, quiet)) =
    run_command_merged(
      "gleam",
      ["test", "--", "--color=never"],
      "examples/playground",
    )
  assert string.contains(quiet, "FAIL  playground_test.background_job_test")
  assert string.contains(
    quiet,
    "Background process crashed at src/playground.gleam:",
  )
  assert string.contains(quiet, "background job crashed: queue is full")
  assert !string.contains(quiet, "Error in process")
  assert !string.contains(quiet, "not charged to any test")

  let assert Ok(#(_, shown)) =
    run_command_merged(
      "gleam",
      ["test", "--", "--color=never", "--show-crash-reports"],
      "examples/playground",
    )
  assert string.contains(
    shown,
    "vouch: 1 crash report captured during the run:",
  )
  // The raw report, after the summary, not interleaved with the results.
  let assert Ok(#(_, after_summary)) =
    string.split_once(shown, "2 passed, 5 failed, 2 todo, 1 skipped")
  assert string.contains(after_summary, "Error in process")
  assert string.contains(after_summary, "background job crashed: queue is full")
}

@target(erlang)
@external(erlang, "vouch_e2e_ffi", "run_command")
fn run_command(
  command: String,
  args: List(String),
  directory: String,
) -> Result(#(Int, String), Nil)

@target(erlang)
@external(erlang, "vouch_e2e_ffi", "run_command_merged")
fn run_command_merged(
  command: String,
  args: List(String),
  directory: String,
) -> Result(#(Int, String), Nil)
