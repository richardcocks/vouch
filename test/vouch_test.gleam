//// vouch's own suite, run under vouch itself. Every test must pass, with
//// the single todo-bodied test reported as skipped — so a green run
//// exercises discovery, execution, panic capture, decoding, classification,
//// and the exit-code rules on both targets.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import helpers
import vouch
import vouch/internal/config
import vouch/internal/event
import vouch/internal/gleam_panic
import vouch/internal/json
import vouch/internal/outcome
import vouch/internal/report/console
import vouch/internal/report/jsonl
import vouch/internal/report/junit
import vouch/internal/runner

pub fn main() -> Nil {
  vouch.main()
}

pub fn passing_test() {
  assert 1 + 1 == 2
}

/// A pending test: vouch must classify this as Skipped, not a failure.
pub fn todo_body_test() {
  todo as "pending test bodies are skipped"
}

// --- Panic decoding ---

pub fn decode_panic_test() {
  let assert Error(raw) = runner.catch_panic(helpers.panics)
  let assert Ok(p) = gleam_panic.from_dynamic(raw)
  assert p.kind == gleam_panic.Panic
  assert p.message == "helper panicked"
  assert p.module == "helpers"
  assert p.function == "panics"
  assert p.line > 0
}

pub fn decode_todo_test() {
  let assert Error(raw) = runner.catch_panic(helpers.unimplemented)
  let assert Ok(p) = gleam_panic.from_dynamic(raw)
  assert p.kind == gleam_panic.Todo
  assert p.message == "unimplemented function in code under test"
  assert p.module == "helpers"
  assert p.function == "unimplemented"
}

pub fn decode_assert_binop_test() {
  let assert Error(raw) = runner.catch_panic(helpers.assert_fails)
  let assert Ok(p) = gleam_panic.from_dynamic(raw)
  let assert gleam_panic.Assert(kind: gleam_panic.BinaryOperator(operator: op, ..), ..) =
    p.kind
  assert op == "=="
}

pub fn decode_assert_call_test() {
  let assert Error(raw) = runner.catch_panic(helpers.assert_call_fails)
  let assert Ok(p) = gleam_panic.from_dynamic(raw)
  let assert gleam_panic.Assert(kind: gleam_panic.FunctionCall(arguments: args), ..) =
    p.kind
  assert list.length(args) == 1
}

pub fn decode_let_assert_test() {
  let assert Error(raw) = runner.catch_panic(helpers.let_assert_fails)
  let assert Ok(p) = gleam_panic.from_dynamic(raw)
  let assert gleam_panic.LetAssert(..) = p.kind
  assert p.function == "let_assert_fails"
}

// --- Outcome classification ---

pub fn classify_pass_test() {
  assert outcome.classify("m", "t", outcome.Passed) == outcome.Pass
}

pub fn classify_skip_vs_todo_test() {
  let p =
    gleam_panic.GleamPanic(
      message: "m",
      file: "f",
      module: "my_test",
      function: "some_test",
      line: 1,
      kind: gleam_panic.Todo,
    )
  assert outcome.classify_panic("my_test", "some_test", p)
    == outcome.Skipped(p)
  assert outcome.classify_panic("my_test", "other_test", p) == outcome.Todo(p)
  assert outcome.classify_panic("other_test", "some_test", p)
    == outcome.Todo(p)
}

pub fn deep_todo_is_todo_outcome_test() {
  let invocation =
    outcome.from_caught(runner.catch_panic(helpers.unimplemented))
  let out =
    outcome.classify("vouch_test", "deep_todo_is_todo_outcome_test", invocation)
  let assert outcome.Todo(p) = out
  assert p.module == "helpers"
}

pub fn panic_is_failure_test() {
  let invocation = outcome.from_caught(runner.catch_panic(helpers.panics))
  let assert outcome.Failed(outcome.PanicDetail(_)) =
    outcome.classify("vouch_test", "panic_is_failure_test", invocation)
}

pub fn timeout_classifies_as_failure_test() {
  assert outcome.classify("m", "t", outcome.TimedOut(100))
    == outcome.Failed(outcome.TimeoutDetail(100))
}

// --- Process isolation (Erlang target only) ---

@target(erlang)
pub fn hanging_test_times_out_test() {
  let invocation = runner.run_in_process("helpers", "sleeps_forever", 100)
  assert invocation == outcome.TimedOut(100)
}

@target(erlang)
pub fn linked_crash_is_contained_test() {
  let invocation = runner.run_in_process("helpers", "crashes_linked", 5000)
  let assert outcome.Failed(outcome.PanicDetail(p)) =
    outcome.classify("vouch_test", "linked_crash_is_contained_test", invocation)
  assert p.message == "crash in linked process"
}

/// A todo inside an OTP process (here a real gen_server callback) reaches
/// the caller wrapped in OTP exit structure. It must still classify as
/// Todo, not an opaque failure.
@target(erlang)
pub fn otp_wrapped_todo_is_todo_outcome_test() {
  let invocation = outcome.from_caught(runner.catch_panic(call_into_todo))
  let assert outcome.Todo(p) =
    outcome.classify(
      "vouch_test",
      "otp_wrapped_todo_is_todo_outcome_test",
      invocation,
    )
  assert p.module == "helpers"
  assert p.function == "unimplemented"
}

@target(erlang)
@external(erlang, "vouch_otp_fixture", "call_into_todo")
fn call_into_todo() -> Nil

@target(erlang)
pub fn isolated_pass_and_panic_test() {
  // failing_result returns an Error value, which is still a *passing* test —
  // only panics fail.
  assert runner.run_in_process("helpers", "failing_result", 5000)
    == outcome.Passed
  let assert outcome.Panicked(raw) =
    runner.run_in_process("helpers", "panics", 5000)
  let assert Ok(p) = gleam_panic.from_dynamic(raw)
  assert p.message == "helper panicked"
}

// --- Tally and exit codes ---

fn sample_todo_panic() -> gleam_panic.GleamPanic {
  gleam_panic.GleamPanic(
    message: "m",
    file: "f",
    module: "some_module",
    function: "some_function",
    line: 1,
    kind: gleam_panic.Todo,
  )
}

pub fn tally_test() {
  let p = sample_todo_panic()
  let outcomes = [
    outcome.Pass,
    outcome.Pass,
    outcome.Skipped(p),
    outcome.Todo(p),
  ]
  assert runner.tally(outcomes)
    == event.Tally(passed: 2, failed: 0, todos: 1, skipped: 1)
}

pub fn exit_code_test() {
  let tally = fn(passed, failed, todos, skipped) {
    event.Tally(passed:, failed:, todos:, skipped:)
  }
  assert runner.exit_code(tally(1, 0, 0, 0)) == 0
  assert runner.exit_code(tally(0, 0, 0, 1)) == 0
  assert runner.exit_code(tally(1, 1, 0, 0)) == 1
  assert runner.exit_code(tally(1, 0, 1, 0)) == 1
  // A run that found no tests at all must fail loudly.
  assert runner.exit_code(tally(0, 0, 0, 0)) == 1
}

// --- Console formatting ---

pub fn format_duration_test() {
  assert console.format_duration(0) == "0.0ms"
  assert console.format_duration(1500) == "1.5ms"
  assert console.format_duration(999_999) == "999.9ms"
  assert console.format_duration(2_500_000) == "2.5s"
}

// --- Config ---

pub fn config_defaults_test() {
  assert config.from_args([])
    == Ok(config.Config(
      format: config.Console,
      filter: None,
      junit: None,
      timeout_ms: config.default_timeout_ms,
    ))
}

pub fn config_format_and_filter_test() {
  assert config.from_args(["--format=json", "--filter=decode"])
    == Ok(config.Config(
      format: config.Json,
      filter: Some("decode"),
      junit: None,
      timeout_ms: config.default_timeout_ms,
    ))
  assert config.from_args([
      "--filter=decode",
      "--junit=report.xml",
      "--timeout=250",
    ])
    == Ok(config.Config(
      format: config.Console,
      filter: Some("decode"),
      junit: Some("report.xml"),
      timeout_ms: 250,
    ))
}

pub fn config_rejects_bad_args_test() {
  let assert Error(_) = config.from_args(["--nope"])
  let assert Error(_) = config.from_args(["--timeout=abc"])
  let assert Error(_) = config.from_args(["--filter=a", "--filter=b"])
  // Bare positional arguments are errors, pointing at --filter.
  let assert Error(message) = config.from_args(["timeout=1"])
  assert string.contains(message, "--filter=timeout=1")
}

// --- JSON encoding ---

pub fn json_escaping_test() {
  assert json.render(json.Str("a\"b\\c\nd")) == "\"a\\\"b\\\\c\\nd\""
}

pub fn json_object_test() {
  assert json.render(json.Obj([#("a", json.Num(1)), #("b", json.Str("x"))]))
    == "{\"a\":1,\"b\":\"x\"}"
}

pub fn jsonl_run_start_test() {
  assert jsonl.event_to_json(event.RunStart(3, 24))
    == "{\"event\":\"run_start\",\"total\":3,\"discovered\":24}"
}

pub fn jsonl_test_result_test() {
  assert jsonl.event_to_json(event.TestResult("m", "f", outcome.Pass, 1500))
    == "{\"event\":\"test_result\",\"module\":\"m\",\"function\":\"f\","
    <> "\"outcome\":\"pass\",\"duration_us\":1500}"
}

pub fn junit_render_test() {
  let p = sample_todo_panic()
  let results = [
    #("mod_a_test", "ok_test", outcome.Pass, 1000),
    #("mod_a_test", "stub_test", outcome.Skipped(p), 500),
    #("mod_b_test", "blocked_test", outcome.Todo(p), 2000),
  ]
  let xml = junit.render(results, 10_000)
  assert string.contains(xml, "<testsuites tests=\"3\" failures=\"1\" skipped=\"1\" time=\"0.010\">")
  assert string.contains(xml, "<testsuite name=\"mod_a_test\" tests=\"2\" failures=\"0\" skipped=\"1\"")
  assert string.contains(xml, "<testcase name=\"ok_test\" classname=\"mod_a_test\" time=\"0.001\"/>")
  assert string.contains(xml, "<skipped message=\"m\"/>")
  assert string.contains(
    xml,
    "<failure type=\"todo\" message=\"blocked on todo at some_module.some_function:1\">m</failure>",
  )
}

pub fn junit_escapes_xml_test() {
  let p =
    gleam_panic.GleamPanic(
      message: "a < b & \"c\"",
      file: "f",
      module: "m",
      function: "f",
      line: 1,
      kind: gleam_panic.Panic,
    )
  let results = [
    #("m_test", "x_test", outcome.Failed(outcome.PanicDetail(p)), 0),
  ]
  let xml = junit.render(results, 0)
  assert string.contains(xml, "message=\"a &lt; b &amp; &quot;c&quot;\"")
}

pub fn jsonl_todo_result_test() {
  let p = sample_todo_panic()
  assert jsonl.event_to_json(event.TestResult("m", "f", outcome.Todo(p), 10))
    == "{\"event\":\"test_result\",\"module\":\"m\",\"function\":\"f\","
    <> "\"outcome\":\"todo\",\"duration_us\":10,\"message\":\"m\","
    <> "\"site_module\":\"some_module\",\"site_function\":\"some_function\","
    <> "\"site_line\":1}"
}
