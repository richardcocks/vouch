//// The per-target execution loops and the narrow FFI contract.

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/string

/// Module name (Gleam form, e.g. "foo/bar_test"), function name, and Ok or
/// the raw caught panic value awaiting decoding.
pub type RawResult =
  #(String, String, Result(Nil, Dynamic))

/// Call a function, capturing any panic as the raw target-specific value.
/// On JavaScript the call is synchronous; async functions are not awaited
/// here (the JavaScript run loop awaits discovered tests itself).
@external(erlang, "vouch_ffi", "catch_panic")
@external(javascript, "../../vouch_ffi.mjs", "catch_panic")
pub fn catch_panic(f: fn() -> a) -> Result(Nil, Dynamic)

@external(erlang, "vouch_ffi", "halt")
@external(javascript, "../../vouch_ffi.mjs", "halt")
pub fn halt(code: Int) -> Nil

// On the Erlang target enumeration and invocation are synchronous, so the
// whole loop is Gleam.

@target(erlang)
pub fn run_tests(report: fn(List(RawResult)) -> Nil) -> Nil {
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
pub fn run_tests(report: fn(List(RawResult)) -> Nil) -> Nil {
  js_run_tests(report)
}

@target(javascript)
@external(javascript, "../../vouch_ffi.mjs", "run_tests")
fn js_run_tests(report: fn(List(RawResult)) -> Nil) -> Nil
