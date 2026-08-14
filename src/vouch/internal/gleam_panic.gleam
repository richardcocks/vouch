//// Typed representation of a Gleam panic, decoded from the raw value a
//// panicking test throws. The decoders live in the FFI because the raw
//// shapes are target-specific: an Erlang map with atom keys, or a JavaScript
//// Error with extra properties. Shapes verified against gleam 1.18.1 on both
//// targets; the structure mirrors gleeunit's internal decoder (Apache-2.0),
//// which types the same compiler-emitted payloads.

import gleam/dynamic

pub type GleamPanic {
  GleamPanic(
    message: String,
    file: String,
    module: String,
    function: String,
    line: Int,
    kind: PanicKind,
  )
}

pub type PanicKind {
  Todo
  Panic
  LetAssert(
    start: Int,
    end: Int,
    pattern_start: Int,
    pattern_end: Int,
    value: dynamic.Dynamic,
  )
  Assert(start: Int, end: Int, expression_start: Int, kind: AssertKind)
}

pub type AssertKind {
  BinaryOperator(
    operator: String,
    left: AssertedExpression,
    right: AssertedExpression,
  )
  FunctionCall(arguments: List(AssertedExpression))
  OtherExpression(expression: AssertedExpression)
}

pub type AssertedExpression {
  AssertedExpression(start: Int, end: Int, kind: ExpressionKind)
}

pub type ExpressionKind {
  Literal(value: dynamic.Dynamic)
  Expression(value: dynamic.Dynamic)
  Unevaluated
}

@external(erlang, "vouch_ffi", "decode_panic")
@external(javascript, "../../vouch_ffi.mjs", "decode_panic")
pub fn from_dynamic(raw: dynamic.Dynamic) -> Result(GleamPanic, Nil)
