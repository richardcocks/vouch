//// vouch's own suite, run under vouch itself. Every test must pass, with
//// the single todo-bodied test reported as skipped — so a green run
//// exercises discovery, execution, panic capture, decoding, classification,
//// and the exit-code rules on both targets.

import gleam/dynamic
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import helpers
import vouch
import vouch/internal/config
import vouch/internal/describe
import vouch/internal/event
import vouch/internal/gleam_panic
import vouch/internal/json
import vouch/internal/outcome
import vouch/internal/report/console
import vouch/internal/report/jsonl
import vouch/internal/report/junit
import vouch/internal/report/teamcity
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
  let assert gleam_panic.Assert(
    kind: gleam_panic.BinaryOperator(operator: op, ..),
    ..,
  ) = p.kind
  assert op == "=="
}

pub fn decode_assert_call_test() {
  let assert Error(raw) = runner.catch_panic(helpers.assert_call_fails)
  let assert Ok(p) = gleam_panic.from_dynamic(raw)
  let assert gleam_panic.Assert(
    kind: gleam_panic.FunctionCall(arguments: args),
    ..,
  ) = p.kind
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
  assert outcome.classify_panic("my_test", "some_test", p) == outcome.Skipped(p)
  assert outcome.classify_panic("my_test", "other_test", p) == outcome.Todo(p)
  assert outcome.classify_panic("other_test", "some_test", p) == outcome.Todo(p)
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

@target(erlang)
/// A todo inside an OTP process (here a real gen_server callback) reaches
/// the caller wrapped in OTP exit structure. It must still classify as
/// Todo, not an opaque failure.
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

@target(erlang)
/// Two 300ms tests awaited together must finish well under the 600ms a
/// sequential run would need: proof the start/await pair actually
/// overlaps execution. The 550ms bound leaves slack for slow CI runners
/// while staying unambiguous.
pub fn parallel_tests_overlap_test() {
  let t0 = monotonic_microseconds()
  let a = runner.start_test("helpers", "sleeps_briefly", 5000)
  let b = runner.start_test("helpers", "sleeps_briefly", 5000)
  let #(invocation_a, duration_a) = runner.await_test(a)
  let #(invocation_b, duration_b) = runner.await_test(b)
  let elapsed_ms = { monotonic_microseconds() - t0 } / 1000
  assert invocation_a == outcome.Passed
  assert invocation_b == outcome.Passed
  assert duration_a >= 300_000
  assert duration_b >= 300_000
  assert elapsed_ms < 550
}

@target(erlang)
/// The parallel path must keep per-test timeout semantics: a started test
/// that outlives its timeout comes back TimedOut from await.
pub fn parallel_test_times_out_test() {
  let handle = runner.start_test("helpers", "sleeps_forever", 100)
  let #(invocation, _) = runner.await_test(handle)
  assert invocation == outcome.TimedOut(100)
}

@target(erlang)
@external(erlang, "vouch_ffi", "now_microseconds")
fn monotonic_microseconds() -> Int

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

// --- Failure wording ---

/// A real failing `assert ==`, decoded from the compiler's own payload,
/// must read as an expectation rather than a field dump.
pub fn describe_assert_equality_test() {
  let assert Error(raw) = runner.catch_panic(helpers.assert_fails)
  let assert Ok(p) = gleam_panic.from_dynamic(raw)
  // helpers.assert_fails is `assert 1 + 1 == 3`.
  assert describe.failure(outcome.PanicDetail(p))
    == ["Expected: 3", "But was:  2"]
}

/// A predicate call is quoted from source: that it returned False is not
/// news, but what was called is.
pub fn describe_assert_call_test() {
  let assert Error(raw) = runner.catch_panic(helpers.assert_call_fails)
  let assert Ok(p) = gleam_panic.from_dynamic(raw)
  // helpers.assert_call_fails is `assert is_even(3)`. The argument needs no
  // line of its own: `3 = 3` would only repeat the quoted call.
  assert describe.failure(outcome.PanicDetail(p))
    == ["Expected: is_even(3) to be True", "But was:  False"]
}

/// An argument written as a name gets a line giving the value behind it.
pub fn describe_assert_call_argument_test() {
  let assert Error(raw) =
    runner.catch_panic(helpers.assert_call_with_binding_fails)
  let assert Ok(p) = gleam_panic.from_dynamic(raw)
  assert describe.failure(outcome.PanicDetail(p))
    == ["Expected: is_even(n) to be True", "But was:  False", "  n = 3"]
}

pub fn describe_assert_expression_test() {
  let assert Error(raw) = runner.catch_panic(helpers.assert_expression_fails)
  let assert Ok(p) = gleam_panic.from_dynamic(raw)
  assert describe.failure(outcome.PanicDetail(p))
    == ["Expected: ready to be True", "But was:  False"]
}

/// The pattern that failed to match is quoted from the source, so the
/// expectation names the shape the test was looking for.
pub fn describe_let_assert_test() {
  let assert Error(raw) = runner.catch_panic(helpers.let_assert_fails)
  let assert Ok(p) = gleam_panic.from_dynamic(raw)
  assert describe.failure(outcome.PanicDetail(p))
    == ["Expected: a value matching Ok(_)", "But was:  Error(\"nope\")"]
}

/// Source quoting is a nicety on top of the payload: when the file behind
/// the offsets cannot be read, every kind still has wording that stands on
/// the payload alone.
pub fn describe_without_source_test() {
  let unreadable = fn(kind) {
    describe.failure(outcome.PanicDetail(
      gleam_panic.GleamPanic(
        ..panic_with(kind),
        file: "test/no_such_file.gleam",
      ),
    ))
  }
  assert unreadable(gleam_panic.Assert(
      start: 0,
      end: 10,
      expression_start: 7,
      kind: gleam_panic.FunctionCall(arguments: [expression(dynamic.int(3))]),
    ))
    == ["Expected: True", "But was:  False", "  argument 1 = 3"]
  assert unreadable(gleam_panic.LetAssert(
      start: 0,
      end: 10,
      pattern_start: 4,
      pattern_end: 9,
      value: dynamic.int(3),
    ))
    == ["Expected: the pattern to match", "But was:  3"]
}

/// Every operator vouch can be handed, in one place: each gets the phrasing
/// that matches how it reads aloud, and each keeps the actual value.
pub fn describe_operators_test() {
  let detail = fn(op) {
    describe.failure(
      outcome.PanicDetail(binop_panic(op, dynamic.int(5), dynamic.int(3))),
    )
  }
  assert detail("==") == ["Expected: 3", "But was:  5"]
  assert detail("!=") == ["Expected: anything except 3", "But was:  5"]
  assert detail("<") == ["Expected: less than 3", "But was:  5"]
  assert detail("<=") == ["Expected: less than or equal to 3", "But was:  5"]
  assert detail(">") == ["Expected: greater than 3", "But was:  5"]
  assert detail(">=") == ["Expected: greater than or equal to 3", "But was:  5"]
  // The float variants of the comparisons read identically.
  assert detail("<.") == detail("<")
  assert detail("<=.") == detail("<=")
  assert detail(">.") == detail(">")
  assert detail(">=.") == detail(">=")
  // An operator vouch has never seen still names both operands.
  assert detail("~~") == ["Expected: 5 ~~ 3 to hold", "But was:  False"]
}

/// `&&` and `||` name the requirement and show both operands, including the
/// short-circuited one — which side was False is the whole answer.
pub fn describe_boolean_operators_test() {
  assert describe.failure(
      outcome.PanicDetail(binop_panic(
        "&&",
        dynamic.bool(True),
        dynamic.bool(False),
      )),
    )
    == ["Expected: both sides True", "But was:  True && False"]
  assert describe.failure(
      outcome.PanicDetail(binop_panic(
        "||",
        dynamic.bool(False),
        dynamic.bool(False),
      )),
    )
    == ["Expected: at least one side True", "But was:  False || False"]
}

/// `assert actual == expected` is the usual shape, so the left operand is
/// the actual value — unless it is a literal, which can only be the
/// expectation.
pub fn describe_orients_literal_as_expected_test() {
  let expected_left =
    gleam_panic.AssertedExpression(
      start: 0,
      end: 1,
      kind: gleam_panic.Literal(dynamic.int(5)),
    )
  let computed_right =
    gleam_panic.AssertedExpression(
      start: 2,
      end: 3,
      kind: gleam_panic.Expression(dynamic.int(4)),
    )
  assert describe.failure(
      outcome.PanicDetail(
        panic_with(gleam_panic.Assert(
          start: 0,
          end: 3,
          expression_start: 0,
          kind: gleam_panic.BinaryOperator(
            operator: "==",
            left: expected_left,
            right: computed_right,
          ),
        )),
      ),
    )
    == ["Expected: 5", "But was:  4"]
}

pub fn describe_timeout_test() {
  assert describe.failure(outcome.TimeoutDetail(100))
    == ["Timed out after 100ms"]
}

/// Windows paths are normalised so the site stays clickable in terminals
/// and editors that only link forward slashes.
pub fn describe_location_test() {
  let p = panic_with(gleam_panic.Panic)
  assert describe.location(
      gleam_panic.GleamPanic(..p, file: "test\\my_test.gleam", line: 28),
    )
    == "test/my_test.gleam:28"
}

fn panic_with(kind: gleam_panic.PanicKind) -> gleam_panic.GleamPanic {
  gleam_panic.GleamPanic(
    message: "Assertion failed.",
    file: "test/my_test.gleam",
    module: "my_test",
    function: "some_test",
    line: 1,
    kind:,
  )
}

/// A synthetic binary-operator panic, standing in for the payloads the
/// compiler emits for operators vouch's own suite cannot fail on demand.
fn binop_panic(
  op: String,
  left: dynamic.Dynamic,
  right: dynamic.Dynamic,
) -> gleam_panic.GleamPanic {
  panic_with(gleam_panic.Assert(
    start: 0,
    end: 0,
    expression_start: 0,
    kind: gleam_panic.BinaryOperator(
      operator: op,
      left: expression(left),
      right: expression(right),
    ),
  ))
}

fn expression(value: dynamic.Dynamic) -> gleam_panic.AssertedExpression {
  gleam_panic.AssertedExpression(
    start: 0,
    end: 0,
    kind: gleam_panic.Expression(value),
  )
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
      color: config.Auto,
      parallel: config.Sequential,
    ))
}

pub fn config_format_and_filter_test() {
  assert config.from_args(["--format=json", "--filter=decode"])
    == Ok(config.Config(
      format: config.Json,
      filter: Some("decode"),
      junit: None,
      timeout_ms: config.default_timeout_ms,
      color: config.Auto,
      parallel: config.Sequential,
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
      color: config.Auto,
      parallel: config.Sequential,
    ))
}

pub fn config_test_name_filter_alias_test() {
  // Zed's Gleam extension runs `gleam test -- --test-name-filter=<function>`.
  assert config.from_args(["--test-name-filter=decode"])
    == config.from_args(["--filter=decode"])
  // The alias shares the single-filter guard with --filter.
  let assert Error(_) = config.from_args(["--filter=a", "--test-name-filter=b"])
  let assert Error(_) =
    config.from_args(["--test-name-filter=a", "--test-name-filter=b"])
}

pub fn config_teamcity_format_test() {
  let assert Ok(config.Config(format: config.TeamCity, ..)) =
    config.from_args(["--format=teamcity"])
}

pub fn config_parallel_test() {
  let assert Ok(config.Config(parallel: config.AutoParallel, ..)) =
    config.from_args(["--parallel"])
  let assert Ok(config.Config(parallel: config.Workers(4), ..)) =
    config.from_args(["--parallel=4"])
  let assert Error(_) = config.from_args(["--parallel=0"])
  let assert Error(_) = config.from_args(["--parallel=lots"])
}

pub fn config_color_test() {
  let assert Ok(config.Config(color: config.Never, ..)) =
    config.from_args(["--color=never"])
  let assert Ok(config.Config(color: config.Always, ..)) =
    config.from_args(["--color=always"])
  let assert Ok(config.Config(color: config.Auto, ..)) = config.from_args([])
}

pub fn config_rejects_bad_args_test() {
  let assert Error(_) = config.from_args(["--nope"])
  let assert Error(_) = config.from_args(["--color=sometimes"])
  let assert Error(_) = config.from_args(["--timeout=abc"])
  // Zero kills every test instantly; a negative value is a timeout_value
  // crash inside the Erlang receive. Both are usage errors, not runs.
  let assert Error(_) = config.from_args(["--timeout=0"])
  let assert Error(_) = config.from_args(["--timeout=-5"])
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
  assert string.contains(
    xml,
    "<testsuites tests=\"3\" failures=\"1\" skipped=\"1\" time=\"0.010\">",
  )
  assert string.contains(
    xml,
    "<testsuite name=\"mod_a_test\" tests=\"2\" failures=\"0\" skipped=\"1\"",
  )
  assert string.contains(
    xml,
    "<testcase name=\"ok_test\" classname=\"mod_a_test\" time=\"0.001\"/>",
  )
  assert string.contains(xml, "<skipped message=\"m\"/>")
  assert string.contains(
    xml,
    "<failure type=\"todo\" message=\"todo at some_module.some_function:1\">m</failure>",
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

/// C0 control characters are invalid in XML 1.0 even as character
/// references, so they are replaced rather than escaped — CI must never be
/// handed an unparseable report because a panic message carried one.
pub fn junit_replaces_control_characters_test() {
  let p =
    gleam_panic.GleamPanic(
      message: "bad\u{0008}byte",
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
  assert string.contains(xml, "message=\"bad\u{fffd}byte\"")
}

// --- TeamCity service messages ---

pub fn teamcity_run_test() {
  let p = sample_todo_panic()
  let #(state, start) = teamcity.step(None, event.RunStart(3, 24))
  assert start == ["##teamcity[testCount count='3']"]

  let #(state, passing) =
    teamcity.step(
      state,
      event.TestResult("mod_a_test", "ok_test", outcome.Pass, 1500),
    )
  assert passing
    == [
      "##teamcity[testSuiteStarted name='mod_a_test']",
      "##teamcity[testStarted name='ok_test']",
      "##teamcity[testFinished name='ok_test' duration='1']",
    ]

  // Same module: the open suite is reused rather than reopened.
  let #(state, skipped) =
    teamcity.step(
      state,
      event.TestResult("mod_a_test", "stub_test", outcome.Skipped(p), 0),
    )
  assert skipped
    == [
      "##teamcity[testStarted name='stub_test']",
      "##teamcity[testIgnored name='stub_test' message='m']",
      "##teamcity[testFinished name='stub_test' duration='0']",
    ]

  // New module: the previous suite closes before the next one opens.
  let #(state, blocked) =
    teamcity.step(
      state,
      event.TestResult("mod_b_test", "blocked_test", outcome.Todo(p), 0),
    )
  assert blocked
    == [
      "##teamcity[testSuiteFinished name='mod_a_test']",
      "##teamcity[testSuiteStarted name='mod_b_test']",
      "##teamcity[testStarted name='blocked_test']",
      "##teamcity[testFailed name='blocked_test' "
        <> "message='todo at some_module.some_function:1' details='m']",
      "##teamcity[testFinished name='blocked_test' duration='0']",
    ]

  let #(_, ending) =
    teamcity.step(
      state,
      event.RunEnd(event.Tally(passed: 1, failed: 0, todos: 1, skipped: 1), 0),
    )
  assert ending == ["##teamcity[testSuiteFinished name='mod_b_test']"]
}

/// Zero tests is a failure vouch states out loud, so the exit code is backed
/// by a build problem rather than an empty, unexplained red step.
pub fn teamcity_no_tests_test() {
  let #(_, lines) =
    teamcity.step(
      None,
      event.RunEnd(event.Tally(passed: 0, failed: 0, todos: 0, skipped: 0), 0),
    )
  assert lines
    == [
      "##teamcity[buildProblem description='vouch ran no tests' "
      <> "identity='vouch_no_tests']",
    ]
}

/// A failing `assert ==` carries its operands as a comparisonFailure, which
/// is what makes TeamCity render its diff view.
pub fn teamcity_comparison_failure_test() {
  let assert Error(raw) = runner.catch_panic(helpers.assert_fails)
  let assert Ok(p) = gleam_panic.from_dynamic(raw)
  let #(_, lines) =
    teamcity.step(
      None,
      event.TestResult(
        "m_test",
        "x_test",
        outcome.Failed(outcome.PanicDetail(p)),
        0,
      ),
    )
  let joined = string.join(lines, "\n")
  assert string.contains(joined, "type='comparisonFailure'")
  // helpers.assert_fails is `assert 1 + 1 == 3`.
  assert string.contains(joined, "actual='2'")
  assert string.contains(joined, "expected='3'")
}

/// The literal-goes-to-expected orientation the console applies (see
/// describe_orients_literal_as_expected_test) must reach the TeamCity diff
/// too, or the two reporters would contradict each other about which value
/// the test expected.
pub fn teamcity_comparison_orients_literal_test() {
  let p =
    panic_with(gleam_panic.Assert(
      start: 0,
      end: 3,
      expression_start: 0,
      kind: gleam_panic.BinaryOperator(
        operator: "==",
        left: gleam_panic.AssertedExpression(
          start: 0,
          end: 1,
          kind: gleam_panic.Literal(dynamic.int(5)),
        ),
        right: gleam_panic.AssertedExpression(
          start: 2,
          end: 3,
          kind: gleam_panic.Expression(dynamic.int(4)),
        ),
      ),
    ))
  let #(_, lines) =
    teamcity.step(
      None,
      event.TestResult(
        "m_test",
        "x_test",
        outcome.Failed(outcome.PanicDetail(p)),
        0,
      ),
    )
  let joined = string.join(lines, "\n")
  assert string.contains(joined, "expected='5'")
  assert string.contains(joined, "actual='4'")
}

pub fn teamcity_escaping_test() {
  let p =
    gleam_panic.GleamPanic(
      message: "it's [broken|odd]\nline two",
      file: "f",
      module: "m",
      function: "f",
      line: 1,
      kind: gleam_panic.Panic,
    )
  let #(_, lines) =
    teamcity.step(
      None,
      event.TestResult(
        "m_test",
        "x_test",
        outcome.Failed(outcome.PanicDetail(p)),
        0,
      ),
    )
  assert string.contains(
    string.join(lines, "\n"),
    "message='it|'s |[broken||odd|]|nline two'",
  )
}

pub fn jsonl_todo_result_test() {
  let p = sample_todo_panic()
  assert jsonl.event_to_json(event.TestResult("m", "f", outcome.Todo(p), 10))
    == "{\"event\":\"test_result\",\"module\":\"m\",\"function\":\"f\","
    <> "\"outcome\":\"todo\",\"duration_us\":10,\"message\":\"m\","
    <> "\"site_module\":\"some_module\",\"site_function\":\"some_function\","
    <> "\"site_line\":1}"
}
