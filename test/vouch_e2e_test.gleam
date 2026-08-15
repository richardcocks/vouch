//// End-to-end tests: run `gleam test` in examples/playground as a
//// subprocess and assert on the JSONL stream and exit code. This is where
//// the deliberately-red outcomes (Fail, Todo, timeouts) get automated
//// coverage that vouch's own green suite cannot host.
////
//// Erlang-target only: one subprocess implementation is enough, and the
//// inner runs cover both targets. These are the slowest tests in the suite
//// (each spawns a full `gleam test`, including the playground's compile
//// check).

import gleam/string

@target(erlang)
pub fn playground_erlang_e2e_test() {
  let assert Ok(#(code, out)) =
    run_command("gleam", ["test", "--", "--format=json"], "examples/playground")
  assert code == 1
  assert string.contains(
    out,
    "\"event\":\"run_end\",\"passed\":2,\"failed\":2,\"todo\":2,\"skipped\":1",
  )
  assert string.contains(out, "\"outcome\":\"todo\"")
  assert string.contains(out, "\"site_function\":\"rate_limit\"")
  // Every stdout line must be a JSON object: the stream stays machine-clean.
  assert out
    |> string.trim
    |> string.split("\n")
    |> all_json_objects
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
  assert string.contains(
    out,
    "\"event\":\"run_end\",\"passed\":2,\"failed\":2,\"todo\":2,\"skipped\":1",
  )
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
    "\"event\":\"run_end\",\"passed\":1,\"failed\":3,\"todo\":2,\"skipped\":1",
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
    "\"event\":\"run_end\",\"passed\":2,\"failed\":2,\"todo\":2,\"skipped\":1",
  )
  assert string.contains(out, "\"site_function\":\"rate_limit\"")
}

@target(erlang)
fn all_json_objects(lines: List(String)) -> Bool {
  case lines {
    [] -> True
    [line, ..rest] ->
      case string.starts_with(line, "{") && string.ends_with(line, "}") {
        True -> all_json_objects(rest)
        False -> False
      }
  }
}

@target(erlang)
@external(erlang, "vouch_e2e_ffi", "run_command")
fn run_command(
  command: String,
  args: List(String),
  directory: String,
) -> Result(#(Int, String), Nil)
