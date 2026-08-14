//// vouch's own suite, run under vouch itself. Every test must pass, with
//// the single todo-bodied test reported as skipped — so a green run
//// exercises discovery, execution, panic capture, decoding, classification,
//// and the exit-code rules on both targets.

import gleam/list
import helpers
import vouch
import vouch/internal/outcome
import vouch/internal/gleam_panic
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
  assert outcome.classify("m", "t", Ok(Nil)) == outcome.Pass
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
  let result = runner.catch_panic(helpers.unimplemented)
  let out =
    outcome.classify("vouch_test", "deep_todo_is_todo_outcome_test", result)
  let assert outcome.Todo(p) = out
  assert p.module == "helpers"
}

pub fn panic_is_failure_test() {
  let result = runner.catch_panic(helpers.panics)
  let assert outcome.Failed(outcome.PanicDetail(_)) =
    outcome.classify("vouch_test", "panic_is_failure_test", result)
}
