//// vouch — a test runner for Gleam. Walking skeleton.
////
//// Discovers `*_test` modules under `test/` containing public zero-arity
//// `*_test` functions, runs them, prints raw outcomes, and exits non-zero on
//// failure. Payload decoding and real reporting come next.

import argv
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string

pub fn main() -> Nil {
  case argv.load().arguments {
    [] -> Nil
    args -> io.println("forwarded args: " <> string.inspect(args))
  }
  run_tests(report)
}

/// Module name (Gleam form, e.g. "foo/bar_test"), function name, and Ok or
/// the raw caught panic value awaiting decoding.
type RawResult =
  #(String, String, Result(Nil, Dynamic))

fn report(results: List(RawResult)) -> Nil {
  list.each(results, fn(raw) {
    let #(module, function, outcome) = raw
    case outcome {
      Ok(Nil) -> io.println("  ok   " <> module <> "." <> function)
      Error(payload) -> {
        io.println("  FAIL " <> module <> "." <> function)
        io.println("       raw payload: " <> string.inspect(payload))
      }
    }
  })
  let total = list.length(results)
  let failed = list.count(results, fn(raw) { result.is_error(raw.2) })
  io.println(
    int.to_string(total) <> " tests, " <> int.to_string(failed) <> " failures",
  )
  case failed {
    0 -> halt(0)
    _ -> halt(1)
  }
}

// On the Erlang target enumeration and invocation are synchronous, so the
// whole loop is Gleam.

@target(erlang)
fn run_tests(report: fn(List(RawResult)) -> Nil) -> Nil {
  let results =
    find_test_files()
    |> list.map(path_to_module)
    |> list.filter(string.ends_with(_, "_test"))
    |> list.flat_map(run_module)
  report(results)
}

@target(erlang)
fn run_module(module: String) -> List(RawResult) {
  exported_zero_arity(module)
  |> list.filter(string.ends_with(_, "_test"))
  |> list.map(fn(function) { #(module, function, run_test(module, function)) })
}

@target(erlang)
fn path_to_module(path: String) -> String {
  path
  |> string.replace("\\", "/")
  |> string.replace(".gleam", "")
}

@target(erlang)
@external(erlang, "vouch_ffi", "find_test_files")
fn find_test_files() -> List(String)

@target(erlang)
@external(erlang, "vouch_ffi", "exported_zero_arity")
fn exported_zero_arity(module: String) -> List(String)

@target(erlang)
@external(erlang, "vouch_ffi", "run_test")
fn run_test(module: String, function: String) -> Result(Nil, Dynamic)

// On the JavaScript target dynamic import and test invocation are async, so
// sequencing lives in the FFI and calls back into Gleam with the results.
// Pulling that sequencing into Gleam (via promise bindings) is future work.

@target(javascript)
fn run_tests(report: fn(List(RawResult)) -> Nil) -> Nil {
  js_run_tests(report)
}

@target(javascript)
@external(javascript, "./vouch_ffi.mjs", "run_tests")
fn js_run_tests(report: fn(List(RawResult)) -> Nil) -> Nil

@external(erlang, "vouch_ffi", "halt")
@external(javascript, "./vouch_ffi.mjs", "halt")
fn halt(code: Int) -> Nil
